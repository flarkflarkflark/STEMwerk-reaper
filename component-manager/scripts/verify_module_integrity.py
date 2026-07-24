#!/usr/bin/env python3
"""Fail-closed, line-ending-safe Go module integrity verification."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


SUMMARY_NAME = "module-integrity-summary.json"
MODULE_FILES = ("go.mod", "go.sum")
SUPPORTED_FAULTS = {
    "cleanup",
    "copy",
    "git_blob_read",
    "summary_write",
    "tempdir_create",
}


class VerificationFailure(Exception):
    """An expected fail-closed verification outcome."""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def normalized(data):
    return data.replace(b"\r\n", b"\n")


def run(command, cwd):
    return subprocess.run(command, cwd=cwd, text=True, capture_output=True)


def run_bytes(command, cwd):
    return subprocess.run(command, cwd=cwd, capture_output=True)


def go_command():
    configured = os.environ.get("MODULE_INTEGRITY_GO_COMMAND")
    if not configured:
        return ["go"]
    parsed = json.loads(configured)
    if not isinstance(parsed, list) or not parsed or not all(isinstance(item, str) and item for item in parsed):
        raise ValueError("MODULE_INTEGRITY_GO_COMMAND must be a non-empty JSON string array")
    return parsed


def write_text(path, value):
    path.write_text(value, encoding="utf-8", newline="\n")


def validate_summary(path):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"invalid module integrity summary: {error}", file=sys.stderr)
        return 1
    required = {
        "schema_version": str,
        "result": str,
        "go_mod_semantic_drift": bool,
        "go_sum_semantic_drift": bool,
        "dependency_set_changed": bool,
        "module_check_execution_location": str,
        "real_checkout_clean_after_module_check": bool,
        "tracked_bytes_changed_by_module_check": int,
    }
    if not isinstance(value, dict) or any(not isinstance(value.get(key), kind) for key, kind in required.items()):
        print("invalid module integrity summary structure", file=sys.stderr)
        return 1
    if value["result"] not in {"PASS", "FAIL"}:
        print("invalid module integrity summary result", file=sys.stderr)
        return 1
    if value["result"] == "PASS" and (
        value["module_check_execution_location"] != "temporary_copy"
        or not value["real_checkout_clean_after_module_check"]
        or value["tracked_bytes_changed_by_module_check"] != 0
    ):
        print("invalid non-mutating module integrity PASS claims", file=sys.stderr)
        return 1
    return 0


def verify(module_dir, evidence_dir):
    module_dir = module_dir.resolve()
    evidence_dir.mkdir(parents=True, exist_ok=True)
    summary_path = evidence_dir / SUMMARY_NAME
    fault = os.environ.get("MODULE_INTEGRITY_FAULT", "")
    summary = {
        "schema_version": "1.0.0",
        "result": "FAIL",
        "go_mod_verify": "NOT_RUN",
        "go_mod_tidy": "NOT_RUN",
        "go_mod_semantic_drift": True,
        "go_sum_semantic_drift": True,
        "dependency_set_changed": True,
        "crlf_only_difference_detected": False,
        "crlf_only_difference_ignored_as_drift": False,
        "module_check_execution_location": "temporary_copy",
        "real_checkout_clean_after_module_check": False,
        "tracked_bytes_changed_by_module_check": 0,
    }

    def finish(result, reason):
        summary["result"] = result
        summary["reason"] = reason
        try:
            if fault == "summary_write":
                raise OSError("injected summary write failure")
            write_text(summary_path, json.dumps(summary, indent=2, sort_keys=True) + "\n")
        except OSError as error:
            print(f"module integrity summary write failed: {error}", file=sys.stderr)
            return 1
        if validate_summary(summary_path) != 0:
            return 1
        print(f"module_integrity={result}")
        print(f"module_integrity_summary={summary_path}")
        return 0 if result == "PASS" else 1

    temporary_root = None
    verification_error = None
    before = {}
    try:
        if fault and fault not in SUPPORTED_FAULTS:
            raise VerificationFailure(f"unsupported fault injection: {fault}")
        missing = [name for name in MODULE_FILES if not (module_dir / name).is_file()]
        if missing:
            raise VerificationFailure("missing module file: " + ", ".join(missing))

        root_result = run(["git", "rev-parse", "--show-toplevel"], module_dir)
        if root_result.returncode != 0:
            raise VerificationFailure("Git repository root unavailable")
        repository_root = Path(root_result.stdout.strip()).resolve()
        try:
            module_relative = module_dir.relative_to(repository_root)
        except ValueError as error:
            raise VerificationFailure(f"module directory outside Git repository: {module_dir}") from error

        initial_status = run(
            ["git", "status", "--porcelain=v1", "--untracked-files=no"],
            repository_root,
        )
        if initial_status.returncode != 0:
            raise VerificationFailure("initial Git worktree status unavailable")
        if initial_status.stdout:
            write_text(evidence_dir / "worktree-status-before.txt", initial_status.stdout)
            raise VerificationFailure("pre-existing tracked worktree change")

        relative_paths = []
        for name in MODULE_FILES:
            path = (module_dir / name).resolve()
            try:
                relative_paths.append(path.relative_to(repository_root).as_posix())
            except ValueError:
                raise VerificationFailure(f"module file outside Git repository: {path}")

        tracked = run(["git", "ls-files", "--error-unmatch", "--", *relative_paths], repository_root)
        if tracked.returncode != 0:
            raise VerificationFailure("module files unavailable in Git index")

        pre_diff = run(
            ["git", "diff", "--exit-code", "--ignore-cr-at-eol", "--", *relative_paths],
            repository_root,
        )
        if pre_diff.returncode != 0:
            write_text(evidence_dir / "module-drift-pre-tidy.diff", pre_diff.stdout + pre_diff.stderr)
            raise VerificationFailure("semantic module drift present before tidy")

        before = {name: (module_dir / name).read_bytes() for name in MODULE_FILES}
        for name, content in before.items():
            stem = name.replace(".", "_")
            summary[f"{stem}_sha_before"] = sha256(content)
            summary[f"normalized_{stem}_sha_before"] = sha256(normalized(content))

        tree_result = run_bytes(
            ["git", "ls-tree", "-r", "--name-only", "-z", "HEAD", "--", module_relative.as_posix()],
            repository_root,
        )
        if tree_result.returncode != 0:
            raise VerificationFailure("tracked module tree unavailable from Git HEAD")
        try:
            tracked_paths = [
                Path(value.decode("utf-8"))
                for value in tree_result.stdout.split(b"\0")
                if value
            ]
        except UnicodeDecodeError as error:
            raise VerificationFailure("tracked module path is not UTF-8") from error
        if not tracked_paths:
            raise VerificationFailure("tracked module tree is empty")

        if fault == "tempdir_create":
            raise OSError("injected temporary directory creation failure")
        temporary_root = Path(tempfile.mkdtemp(prefix="stemwerk-module-integrity-"))
        temporary_module = temporary_root / "module"
        temporary_module.mkdir()
        normative = {}
        for index, repository_path in enumerate(tracked_paths):
            if fault == "copy" and index == 0:
                raise OSError("injected temporary copy failure")
            if fault == "git_blob_read" and repository_path.name in MODULE_FILES:
                raise VerificationFailure("injected Git blob read failure")
            blob_result = run_bytes(
                ["git", "show", f"HEAD:{repository_path.as_posix()}"],
                repository_root,
            )
            if blob_result.returncode != 0:
                raise VerificationFailure(f"Git blob unavailable: {repository_path.as_posix()}")
            try:
                relative = repository_path.relative_to(module_relative)
            except ValueError as error:
                raise VerificationFailure("tracked module path escaped module directory") from error
            target = temporary_module / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(blob_result.stdout)
            if relative.as_posix() in MODULE_FILES:
                normative[relative.as_posix()] = blob_result.stdout
        missing_blobs = [name for name in MODULE_FILES if name not in normative]
        if missing_blobs:
            raise VerificationFailure("module Git blob missing: " + ", ".join(missing_blobs))

        go = go_command()
        verify_result = run([*go, "mod", "verify"], temporary_module)
        write_text(evidence_dir / "go-mod-verify.txt", verify_result.stdout + verify_result.stderr)
        if verify_result.returncode != 0:
            summary["go_mod_verify"] = "FAIL"
            raise VerificationFailure("go mod verify failed")
        summary["go_mod_verify"] = "PASS"

        dependencies_before = run([*go, "list", "-m", "all"], temporary_module)
        if dependencies_before.returncode != 0:
            raise VerificationFailure("dependency set capture before tidy failed")
        before_set = sorted(set(dependencies_before.stdout.splitlines()))
        write_text(evidence_dir / "modules-before.txt", "\n".join(before_set) + "\n")

        tidy_result = run([*go, "mod", "tidy"], temporary_module)
        write_text(evidence_dir / "go-mod-tidy.txt", tidy_result.stdout + tidy_result.stderr)
        if tidy_result.returncode != 0:
            summary["go_mod_tidy"] = "FAIL"
            raise VerificationFailure("go mod tidy failed")
        summary["go_mod_tidy"] = "PASS"

        dependencies_after = run([*go, "list", "-m", "all"], temporary_module)
        if dependencies_after.returncode != 0:
            raise VerificationFailure("dependency set capture after tidy failed")
        after_set = sorted(set(dependencies_after.stdout.splitlines()))
        write_text(evidence_dir / "modules-after.txt", "\n".join(after_set) + "\n")
        summary["dependency_set_changed"] = before_set != after_set

        try:
            after = {name: (temporary_module / name).read_bytes() for name in MODULE_FILES}
        except OSError as error:
            raise VerificationFailure(f"temporary module file unavailable after tidy: {error}") from error
        for name, content in after.items():
            stem = name.replace(".", "_")
            summary[f"{stem}_sha_after"] = sha256(content)
            summary[f"normalized_{stem}_sha_after"] = sha256(normalized(content))

        normalized_equal = {
            name: normalized(normative[name]) == normalized(after[name]) for name in MODULE_FILES
        }
        summary["go_mod_semantic_drift"] = not normalized_equal["go.mod"]
        summary["go_sum_semantic_drift"] = not normalized_equal["go.sum"]
        raw_changed = any(before[name] != after[name] for name in MODULE_FILES)
        summary["crlf_only_difference_detected"] = (
            raw_changed
            and all(normalized(before[name]) == normalized(after[name]) for name in MODULE_FILES)
        )
        summary["crlf_only_difference_ignored_as_drift"] = summary["crlf_only_difference_detected"]

        if summary["go_mod_semantic_drift"] or summary["go_sum_semantic_drift"]:
            raise VerificationFailure("semantic module drift detected after tidy")
        if summary["dependency_set_changed"]:
            raise VerificationFailure("dependency set changed after tidy")
    except VerificationFailure as error:
        verification_error = str(error)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        verification_error = f"integrity verifier infrastructure failure: {error}"
    finally:
        if temporary_root is not None:
            try:
                shutil.rmtree(temporary_root)
                if fault == "cleanup":
                    raise OSError("injected temporary cleanup failure")
            except OSError as error:
                verification_error = f"temporary module cleanup failed: {error}"

    if before:
        try:
            actual_after = {name: (module_dir / name).read_bytes() for name in MODULE_FILES}
            summary["tracked_bytes_changed_by_module_check"] = sum(
                before[name] != actual_after[name] for name in MODULE_FILES
            )
            final_status = run(
                ["git", "status", "--porcelain=v1", "--untracked-files=no"],
                repository_root,
            )
            if final_status.returncode != 0:
                verification_error = "final Git worktree status unavailable"
            elif final_status.stdout:
                write_text(evidence_dir / "worktree-status-after.txt", final_status.stdout)
                verification_error = "tracked worktree changed during verification"
            elif summary["tracked_bytes_changed_by_module_check"]:
                verification_error = "module checkout bytes changed during verification"
            else:
                summary["real_checkout_clean_after_module_check"] = True
        except OSError as error:
            verification_error = f"final checkout verification failed: {error}"

    if verification_error:
        return finish("FAIL", verification_error)
    return finish("PASS", "module files and dependency set unchanged; real checkout untouched")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--module-dir", type=Path)
    parser.add_argument("--evidence-dir", type=Path)
    parser.add_argument("--validate-summary", type=Path)
    args = parser.parse_args()
    if args.validate_summary:
        if args.module_dir or args.evidence_dir:
            parser.error("--validate-summary cannot be combined with verification arguments")
        return validate_summary(args.validate_summary)
    if not args.module_dir or not args.evidence_dir:
        parser.error("--module-dir and --evidence-dir are required")
    return verify(args.module_dir, args.evidence_dir.resolve())


if __name__ == "__main__":
    sys.exit(main())
