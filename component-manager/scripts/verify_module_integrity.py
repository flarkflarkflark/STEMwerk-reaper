#!/usr/bin/env python3
"""Fail-closed, line-ending-safe Go module integrity verification."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


SUMMARY_NAME = "module-integrity-summary.json"
MODULE_FILES = ("go.mod", "go.sum")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def normalized(data):
    return data.replace(b"\r\n", b"\n")


def run(command, cwd):
    return subprocess.run(command, cwd=cwd, text=True, capture_output=True)


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
    }
    if not isinstance(value, dict) or any(not isinstance(value.get(key), kind) for key, kind in required.items()):
        print("invalid module integrity summary structure", file=sys.stderr)
        return 1
    if value["result"] not in {"PASS", "FAIL"}:
        print("invalid module integrity summary result", file=sys.stderr)
        return 1
    return 0


def verify(module_dir, evidence_dir):
    module_dir = module_dir.resolve()
    evidence_dir.mkdir(parents=True, exist_ok=True)
    summary_path = evidence_dir / SUMMARY_NAME
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
    }

    def finish(result, reason):
        summary["result"] = result
        summary["reason"] = reason
        write_text(summary_path, json.dumps(summary, indent=2, sort_keys=True) + "\n")
        if validate_summary(summary_path) != 0:
            return 1
        print(f"module_integrity={result}")
        print(f"module_integrity_summary={summary_path}")
        return 0 if result == "PASS" else 1

    try:
        missing = [name for name in MODULE_FILES if not (module_dir / name).is_file()]
        if missing:
            return finish("FAIL", "missing module file: " + ", ".join(missing))

        root_result = run(["git", "rev-parse", "--show-toplevel"], module_dir)
        if root_result.returncode != 0:
            return finish("FAIL", "Git repository root unavailable")
        repository_root = Path(root_result.stdout.strip()).resolve()
        relative_paths = []
        for name in MODULE_FILES:
            path = (module_dir / name).resolve()
            try:
                relative_paths.append(path.relative_to(repository_root).as_posix())
            except ValueError:
                return finish("FAIL", f"module file outside Git repository: {path}")

        tracked = run(["git", "ls-files", "--error-unmatch", "--", *relative_paths], repository_root)
        if tracked.returncode != 0:
            return finish("FAIL", "module files unavailable in Git index")

        pre_diff = run(
            ["git", "diff", "--exit-code", "--ignore-cr-at-eol", "--", *relative_paths],
            repository_root,
        )
        if pre_diff.returncode != 0:
            write_text(evidence_dir / "module-drift-pre-tidy.diff", pre_diff.stdout + pre_diff.stderr)
            return finish("FAIL", "semantic module drift present before tidy")

        before = {name: (module_dir / name).read_bytes() for name in MODULE_FILES}
        for name, content in before.items():
            stem = name.replace(".", "_")
            summary[f"{stem}_sha_before"] = sha256(content)
            summary[f"normalized_{stem}_sha_before"] = sha256(normalized(content))

        go = go_command()
        verify_result = run([*go, "mod", "verify"], module_dir)
        write_text(evidence_dir / "go-mod-verify.txt", verify_result.stdout + verify_result.stderr)
        if verify_result.returncode != 0:
            summary["go_mod_verify"] = "FAIL"
            return finish("FAIL", "go mod verify failed")
        summary["go_mod_verify"] = "PASS"

        dependencies_before = run([*go, "list", "-m", "all"], module_dir)
        if dependencies_before.returncode != 0:
            return finish("FAIL", "dependency set capture before tidy failed")
        before_set = sorted(set(dependencies_before.stdout.splitlines()))
        write_text(evidence_dir / "modules-before.txt", "\n".join(before_set) + "\n")

        tidy_result = run([*go, "mod", "tidy"], module_dir)
        write_text(evidence_dir / "go-mod-tidy.txt", tidy_result.stdout + tidy_result.stderr)
        if tidy_result.returncode != 0:
            summary["go_mod_tidy"] = "FAIL"
            return finish("FAIL", "go mod tidy failed")
        summary["go_mod_tidy"] = "PASS"

        dependencies_after = run([*go, "list", "-m", "all"], module_dir)
        if dependencies_after.returncode != 0:
            return finish("FAIL", "dependency set capture after tidy failed")
        after_set = sorted(set(dependencies_after.stdout.splitlines()))
        write_text(evidence_dir / "modules-after.txt", "\n".join(after_set) + "\n")
        summary["dependency_set_changed"] = before_set != after_set

        after = {name: (module_dir / name).read_bytes() for name in MODULE_FILES}
        for name, content in after.items():
            stem = name.replace(".", "_")
            summary[f"{stem}_sha_after"] = sha256(content)
            summary[f"normalized_{stem}_sha_after"] = sha256(normalized(content))

        semantic_diff = run(
            ["git", "diff", "--exit-code", "--ignore-cr-at-eol", "--", *relative_paths],
            repository_root,
        )
        if semantic_diff.returncode not in (0, 1):
            return finish("FAIL", "Git/index comparison failed")
        if semantic_diff.returncode == 1:
            detailed_diff = run(
                ["git", "diff", "--ignore-cr-at-eol", "--", *relative_paths],
                repository_root,
            )
            write_text(evidence_dir / "module-drift-after-tidy.diff", detailed_diff.stdout + detailed_diff.stderr)

        normalized_equal = {
            name: normalized(before[name]) == normalized(after[name]) for name in MODULE_FILES
        }
        summary["go_mod_semantic_drift"] = semantic_diff.returncode == 1 or not normalized_equal["go.mod"]
        summary["go_sum_semantic_drift"] = semantic_diff.returncode == 1 or not normalized_equal["go.sum"]
        raw_changed = any(before[name] != after[name] for name in MODULE_FILES)
        summary["crlf_only_difference_detected"] = raw_changed and all(normalized_equal.values())
        summary["crlf_only_difference_ignored_as_drift"] = summary["crlf_only_difference_detected"]

        if summary["go_mod_semantic_drift"] or summary["go_sum_semantic_drift"]:
            return finish("FAIL", "semantic module drift detected after tidy")
        if summary["dependency_set_changed"]:
            return finish("FAIL", "dependency set changed after tidy")
        return finish("PASS", "module files and dependency set unchanged")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return finish("FAIL", f"integrity verifier infrastructure failure: {error}")


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
