#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def run(command, *, cwd, input_bytes=None):
    return subprocess.run(command, cwd=cwd, input=input_bytes, capture_output=True)


def load_gofmt_command():
    raw = os.environ.get("GO_FORMAT_GOFMT_COMMAND")
    if raw is None:
        return ["gofmt"]
    command = json.loads(raw)
    if not isinstance(command, list) or not command or not all(isinstance(part, str) and part for part in command):
        raise ValueError("GO_FORMAT_GOFMT_COMMAND must be a non-empty JSON string array")
    return command


def valid_gofmt_diff(output):
    return output.startswith(b"diff ") and b"\n--- " in output and b"\n+++ " in output


def write_summary(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")


def verify(module_dir, summary_path):
    payload = {
        "schema_version": "1.0.0",
        "result": "ERROR",
        "source": "git-head-blobs",
        "module_dir": str(module_dir),
        "gofmt_command": [],
        "tracked_go_file_count": 0,
        "nonconformant_file_count": 0,
        "nonconformant_files": [],
        "files_rewritten": 0,
        "error": None,
    }
    try:
        module_dir = module_dir.resolve(strict=True)
        root_result = run(["git", "rev-parse", "--show-toplevel"], cwd=module_dir)
        if root_result.returncode != 0:
            raise RuntimeError("Git repository root unavailable: " + root_result.stderr.decode(errors="replace").strip())
        repository = Path(root_result.stdout.decode().strip()).resolve()
        try:
            module_relative = module_dir.relative_to(repository)
        except ValueError as exc:
            raise RuntimeError("module directory is outside the Git repository") from exc

        pathspec = module_relative.as_posix() if module_relative.parts else "."
        files_result = run(["git", "ls-files", "-z", "--", pathspec], cwd=repository)
        if files_result.returncode != 0:
            raise RuntimeError("tracked file enumeration failed: " + files_result.stderr.decode(errors="replace").strip())
        prefix = "" if pathspec == "." else pathspec.rstrip("/") + "/"
        repository_paths = sorted(
            path.decode("utf-8")
            for path in files_result.stdout.split(b"\0")
            if path and path.decode("utf-8").endswith(".go")
        )
        display_paths = [path[len(prefix):] if path.startswith(prefix) else path for path in repository_paths]
        payload["module_dir"] = pathspec
        payload["tracked_go_file_count"] = len(repository_paths)

        gofmt_command = load_gofmt_command()
        payload["gofmt_command"] = [*gofmt_command, "-d"]
        nonconformant = []
        for repository_path, display_path in zip(repository_paths, display_paths):
            blob_result = run(["git", "show", f"HEAD:{repository_path}"], cwd=repository)
            if blob_result.returncode != 0:
                raise RuntimeError(f"Git blob unavailable for {display_path}: " + blob_result.stderr.decode(errors="replace").strip())
            try:
                format_result = run([*gofmt_command, "-d"], cwd=module_dir, input_bytes=blob_result.stdout)
            except OSError as exc:
                raise RuntimeError(f"gofmt unavailable for {display_path}: {exc}") from exc
            if format_result.returncode not in (0, 1):
                detail = format_result.stderr.decode(errors="replace").strip()
                raise RuntimeError(f"gofmt failed for {display_path} with exit {format_result.returncode}: {detail}")
            if format_result.stderr:
                raise RuntimeError(f"gofmt emitted unexpected stderr for {display_path}: " + format_result.stderr.decode(errors="replace").strip())
            if format_result.stdout:
                if not valid_gofmt_diff(format_result.stdout):
                    raise RuntimeError(f"gofmt emitted malformed diff output for {display_path}")
                nonconformant.append(display_path)
            elif format_result.returncode != 0:
                raise RuntimeError(f"gofmt failed for {display_path} with exit {format_result.returncode} and no diff")

        payload["nonconformant_files"] = nonconformant
        payload["nonconformant_file_count"] = len(nonconformant)
        payload["result"] = "FAIL" if nonconformant else "PASS"
        write_summary(summary_path, payload)
        print(f"go_format={payload['result']}")
        print(f"go_format_summary={summary_path}")
        return 1 if nonconformant else 0
    except (json.JSONDecodeError, OSError, RuntimeError, ValueError) as exc:
        payload["error"] = str(exc)
        write_summary(summary_path, payload)
        print("go_format=ERROR")
        print(f"go_format_summary={summary_path}")
        print(str(exc), file=sys.stderr)
        return 2


def main():
    parser = argparse.ArgumentParser(description="Verify tracked Go blobs are gofmt-conformant")
    parser.add_argument("--module-dir", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    args = parser.parse_args()
    return verify(args.module_dir, args.summary)


if __name__ == "__main__":
    sys.exit(main())
