"""Static + executable proof that release-installers.yml separates BUILD
provenance (an unpublished RC, built from an exact pinned commit, no tag
required yet) from PUBLICATION provenance (requires an existing tag that
resolves to that exact commit, and republishes the prior build's artifact
bytes rather than rebuilding).

The gate logic lives in real `run:` bash blocks inside the workflow YAML.
Rather than re-describing that logic in Python (which could drift from what
actually runs), these tests extract the exact script text from the parsed
YAML, substitute the `${{ ... }}` GitHub Actions expressions with test
values the same way the real runner would, and execute the result against a
real throwaway git repo -- fully hermetic, no GitHub Actions runner or
network involved.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = ROOT / ".github/workflows/release-installers.yml"

_EXPR_RE = re.compile(r"\$\{\{\s*(.+?)\s*\}\}")


def _load_workflow() -> dict:
    return yaml.safe_load(WORKFLOW_PATH.read_text(encoding="utf-8"))


def _job(workflow: dict, name: str) -> dict:
    return workflow["jobs"][name]


def _step_by_name(steps: list[dict], name: str) -> dict:
    for step in steps:
        if step.get("name") == name:
            return step
    raise AssertionError(f"step {name!r} not found; have {[s.get('name') for s in steps]}")


def _render(text: str, subs: dict[str, str]) -> str:
    def repl(match: re.Match) -> str:
        expr = match.group(1).strip()
        if expr not in subs:
            raise AssertionError(f"no test substitution provided for expression: {expr!r}")
        return subs[expr]

    return _EXPR_RE.sub(repl, text)


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True, text=True)


def _init_repo(tmp_path: Path, version: str = "2.3.1.2") -> tuple[Path, str]:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    (repo / "VERSION").write_text(version + "\n", encoding="utf-8")
    _git(repo, "add", "VERSION")
    _git(repo, "commit", "-q", "-m", "initial")
    sha = _git(repo, "rev-parse", "HEAD").stdout.strip()
    return repo, sha


def _run_bash(repo: Path, script: str, extra_env: dict[str, str] | None = None):
    github_output = repo / "github_output.txt"
    github_output.write_text("", encoding="utf-8")
    env = os.environ.copy()
    env["GITHUB_OUTPUT"] = str(github_output)
    env["STEMWERK_VERSION_FILE"] = "VERSION"
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        ["bash", "-c", script],
        cwd=repo,
        capture_output=True,
        text=True,
        env=env,
    )
    outputs: dict[str, str] = {}
    for line in github_output.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            outputs[key] = value
    return result, outputs


@pytest.fixture(scope="module")
def resolve_mode_steps() -> list[dict]:
    workflow = _load_workflow()
    return _job(workflow, "resolve-mode")["steps"]


def _resolve_step_script(steps: list[dict], source_commit: str, tag: str, upload: str) -> str:
    step = _step_by_name(steps, "Resolve BUILD vs PUBLICATION mode and validate the exact source commit")
    return _render(
        step["run"],
        {
            "github.event.inputs.source_commit": source_commit,
            "github.event.inputs.tag": tag,
            "github.event.inputs.upload_release_assets": upload,
        },
    )


# --- 1: RC build accepts an exact full commit SHA without a tag -----------


def test_build_mode_accepts_exact_commit_sha_without_tag(tmp_path, resolve_mode_steps):
    repo, sha = _init_repo(tmp_path)
    script = _resolve_step_script(resolve_mode_steps, sha, "", "false")

    result, outputs = _run_bash(repo, script)

    assert result.returncode == 0, result.stderr
    assert outputs["mode"] == "build"
    assert outputs["source_commit"] == sha
    assert outputs["version"] == "2.3.1.2"
    assert outputs["release_tag"] == "v2.3.1.2"


def test_build_mode_does_not_require_release_tag_to_exist(tmp_path, resolve_mode_steps):
    repo, sha = _init_repo(tmp_path)
    assert _git(repo, "tag", "--list").stdout.strip() == ""  # no tags at all

    script = _resolve_step_script(resolve_mode_steps, sha, "", "false")
    result, outputs = _run_bash(repo, script)

    assert result.returncode == 0, result.stderr
    assert outputs["mode"] == "build"


# --- 2: RC build rejects branch names / floating refs ----------------------


@pytest.mark.parametrize("floating_ref", ["main", "release/2.3.1.2-rc-prep", "v2.3.1.2", "HEAD", "latest"])
def test_build_mode_rejects_branch_and_tag_names(tmp_path, resolve_mode_steps, floating_ref):
    repo, sha = _init_repo(tmp_path)
    script = _resolve_step_script(resolve_mode_steps, floating_ref, "", "false")

    result, _outputs = _run_bash(repo, script)

    assert result.returncode != 0
    assert "must be a full 40-hex commit SHA" in result.stdout + result.stderr


def test_build_mode_rejects_source_commit_not_matching_actual_checkout(tmp_path, resolve_mode_steps):
    """source_commit must match what was actually checked out (HEAD) -- a
    caller can't claim a different commit than the one the runner resolved."""
    repo, sha = _init_repo(tmp_path)
    (repo / "extra.txt").write_text("second commit\n", encoding="utf-8")
    _git(repo, "add", "extra.txt")
    _git(repo, "commit", "-q", "-m", "second")
    other_sha = _git(repo, "rev-parse", "HEAD").stdout.strip()
    assert other_sha != sha

    # HEAD is actually other_sha, but the workflow was asked to validate
    # against the first commit's SHA -- must fail closed.
    script = _resolve_step_script(resolve_mode_steps, sha, "", "false")
    result, _outputs = _run_bash(repo, script)

    assert result.returncode != 0
    assert "does not match requested source_commit" in result.stdout + result.stderr


# --- 6: upload_release_assets defaults to false -----------------------------


def test_upload_release_assets_defaults_to_false():
    workflow = _load_workflow()
    # PyYAML parses the bare YAML 1.1 scalar `on:` as the boolean True key.
    inputs = workflow[True]["workflow_dispatch"]["inputs"]
    assert inputs["upload_release_assets"]["default"] == "false"


def test_source_commit_input_is_required():
    workflow = _load_workflow()
    # PyYAML parses the bare YAML 1.1 scalar `on:` as the boolean True key.
    inputs = workflow[True]["workflow_dispatch"]["inputs"]
    assert inputs["source_commit"]["required"] is True


# --- 3/4/5: publication tag/commit parity gate -----------------------------


@pytest.fixture(scope="module")
def publication_tag_gate_script(resolve_mode_steps) -> str:
    step = _step_by_name(resolve_mode_steps, "Publication gate: release tag must exist and resolve to source_commit")
    assert step.get("if") == "${{ github.event.inputs.upload_release_assets == 'true' }}"
    return step["run"]


def test_publication_rejects_missing_tag(tmp_path, publication_tag_gate_script):
    repo, sha = _init_repo(tmp_path)
    # No tag created at all.
    result, _outputs = _run_bash(
        repo,
        publication_tag_gate_script,
        extra_env={"RELEASE_TAG": "v2.3.1.2", "SOURCE_COMMIT": sha},
    )

    assert result.returncode != 0
    assert "does not exist" in result.stdout + result.stderr


def test_publication_rejects_tag_pointing_at_a_different_commit(tmp_path, publication_tag_gate_script):
    repo, first_sha = _init_repo(tmp_path)
    _git(repo, "tag", "v2.3.1.2")  # tags the first commit

    (repo / "extra.txt").write_text("second commit\n", encoding="utf-8")
    _git(repo, "add", "extra.txt")
    _git(repo, "commit", "-q", "-m", "second")
    second_sha = _git(repo, "rev-parse", "HEAD").stdout.strip()
    assert second_sha != first_sha

    # Validating against the second commit, but the tag points at the first.
    result, _outputs = _run_bash(
        repo,
        publication_tag_gate_script,
        extra_env={"RELEASE_TAG": "v2.3.1.2", "SOURCE_COMMIT": second_sha},
    )

    assert result.returncode != 0
    assert "not the requested source_commit" in result.stdout + result.stderr


def test_publication_accepts_tag_pointing_at_exact_requested_commit(tmp_path, publication_tag_gate_script):
    repo, sha = _init_repo(tmp_path)
    _git(repo, "tag", "v2.3.1.2")

    result, _outputs = _run_bash(
        repo,
        publication_tag_gate_script,
        extra_env={"RELEASE_TAG": "v2.3.1.2", "SOURCE_COMMIT": sha},
    )

    assert result.returncode == 0, result.stderr


def test_publication_gate_only_runs_when_upload_release_assets_is_true(resolve_mode_steps):
    step = _step_by_name(resolve_mode_steps, "Publication gate: release tag must exist and resolve to source_commit")
    assert step["if"] == "${{ github.event.inputs.upload_release_assets == 'true' }}"
    build_run_step = _step_by_name(resolve_mode_steps, "Publication gate: require the prior validated build run")
    assert build_run_step["if"] == "${{ github.event.inputs.upload_release_assets == 'true' }}"


# --- bonus: publication requires a prior validated build run (no rebuild) --


def test_publication_requires_build_run_id(tmp_path, resolve_mode_steps):
    step = _step_by_name(resolve_mode_steps, "Publication gate: require the prior validated build run")
    script = _render(step["run"], {"github.event.inputs.build_run_id": ""})
    repo, _sha = _init_repo(tmp_path)

    result, _outputs = _run_bash(repo, script)

    assert result.returncode != 0
    assert "requires build_run_id" in result.stdout + result.stderr


def test_publication_proceeds_with_a_build_run_id_supplied(tmp_path, resolve_mode_steps):
    step = _step_by_name(resolve_mode_steps, "Publication gate: require the prior validated build run")
    script = _render(step["run"], {"github.event.inputs.build_run_id": "123456789"})
    repo, _sha = _init_repo(tmp_path)

    result, _outputs = _run_bash(repo, script)

    assert result.returncode == 0, result.stderr


def test_publish_job_downloads_from_the_validated_build_run_and_never_builds():
    workflow = _load_workflow()
    publish = _job(workflow, "publish")
    assert publish["needs"] == "resolve-mode"
    assert publish["if"] == "${{ needs.resolve-mode.outputs.mode == 'publish' }}"

    step_names = [s.get("name", "") for s in publish["steps"]]
    assert "Download validated build artifacts and checksum manifest" in step_names
    assert "Publish release assets" in step_names
    # No build tooling invoked in the publish job -- it only downloads and uploads.
    joined = "\n".join(str(s) for s in publish["steps"])
    for forbidden in ("ISCC.exe", "build_pkg.sh", "build_appimage.sh"):
        assert forbidden not in joined

    download_step = _step_by_name(publish["steps"], "Download validated build artifacts and checksum manifest")
    assert download_step["with"]["run-id"] == "${{ github.event.inputs.build_run_id }}"
    assert "github-token" in download_step["with"]


def test_build_jobs_gated_on_build_mode_and_checkout_the_exact_source_commit():
    workflow = _load_workflow()
    for job_name in ("windows-exe", "macos-pkg", "linux-packages", "checksums"):
        job = _job(workflow, job_name)
        assert job["if"] == "${{ needs.resolve-mode.outputs.mode == 'build' }}", job_name

    for job_name in ("windows-exe", "macos-pkg", "linux-packages"):
        job = _job(workflow, job_name)
        checkout_step = job["steps"][0]
        assert checkout_step["with"]["ref"] == "${{ needs.resolve-mode.outputs.source_commit }}", job_name


# --- 7: five-artifact matrix unchanged --------------------------------------


def test_five_artifact_matrix_unchanged():
    workflow = _load_workflow()
    checksums_script = _step_by_name(
        _job(workflow, "checksums")["steps"], "Generate combined checksum manifest"
    )["run"]

    for expected in (
        "STEMwerk-Setup-$STEMWERK_VERSION.exe",
        "STEMwerk-Setup-$STEMWERK_VERSION-bundled.exe",
        "STEMwerk-$STEMWERK_VERSION.pkg",
        "STEMwerk-$STEMWERK_VERSION-bundled-apple-silicon.pkg",
        "STEMwerk-$STEMWERK_VERSION-x86_64.AppImage",
    ):
        assert expected in checksums_script

    publish = _job(workflow, "publish")
    publish_files = _step_by_name(publish["steps"], "Publish release assets")["with"]["files"]
    assert "artifacts/STEMwerk-Setup-*.exe" in publish_files
    assert "artifacts/*.pkg" in publish_files
    assert "artifacts/*.AppImage" in publish_files
    assert "artifacts/SHA256SUMS-*.txt" in publish_files
    for forbidden in (".deb", ".rpm", ".pkg.tar.zst"):
        assert forbidden not in publish_files


# --- 8: checksum job unchanged ----------------------------------------------


def test_checksums_job_unchanged():
    workflow = _load_workflow()
    checksums = _job(workflow, "checksums")
    assert set(checksums["needs"]) == {"resolve-mode", "windows-exe", "macos-pkg", "linux-packages"}

    step_names = [s.get("name", "") for s in checksums["steps"]]
    assert "Download built installers" in step_names
    assert "Generate combined checksum manifest" in step_names
    assert "Upload checksum manifest" in step_names

    upload_step = _step_by_name(checksums["steps"], "Upload checksum manifest")
    assert upload_step["with"]["name"] == "installers-checksums"
