#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys


DIGEST = re.compile(r"[0-9a-f]{64}")


def git_command():
    raw = os.environ.get("SCHEMA_AUTHORITY_GIT_COMMAND")
    if raw is None:
        return ["git"]
    command = json.loads(raw)
    if not isinstance(command, list) or not command or not all(isinstance(part, str) and part for part in command):
        raise ValueError("SCHEMA_AUTHORITY_GIT_COMMAND must be a non-empty JSON string array")
    return command


def run_git(command, repository, *args):
    result = subprocess.run([*command, "-C", str(repository), *args], capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(f"Git command failed ({' '.join(args)}): " + result.stderr.decode(errors="replace").strip())
    return result.stdout


def parse_manifest(data):
    entries = {}
    for raw_line in data.decode("utf-8").splitlines():
        fields = raw_line.split()
        if len(fields) != 2:
            raise ValueError(f"invalid manifest line {raw_line!r}")
        digest, name = fields
        path = PurePosixPath(name)
        if not DIGEST.fullmatch(digest):
            raise ValueError(f"invalid manifest digest for {name!r}")
        if path.is_absolute() or len(path.parts) != 1 or path.name != name or name in (".", ".."):
            raise ValueError(f"invalid manifest path {name!r}")
        if name in entries:
            raise ValueError(f"duplicate manifest entry {name!r}")
        entries[name] = digest
    return entries


def tree_names(command, repository, directory):
    output = run_git(command, repository, "ls-tree", "-z", "--name-only", f"HEAD:{directory}")
    return sorted(name.decode("utf-8") for name in output.split(b"\0") if name and name.endswith(b".schema.json"))


def blob(command, repository, path):
    return run_git(command, repository, "show", f"HEAD:{path}")


def write_summary(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")


def validate_summary(path):
    payload = json.loads(path.read_text(encoding="utf-8"))
    required = {
        "schema_version", "result", "authority", "expected_schema_count", "git_blob_schema_count",
        "embedded_schema_count", "manifest_schema_count", "git_blob_embedded_match_count",
        "git_blob_manifest_match_count", "worktree_diagnostic_mismatch_count", "files_rewritten",
    }
    if not isinstance(payload, dict) or not required <= payload.keys() or payload["result"] not in ("PASS", "FAIL"):
        raise ValueError("invalid schema authority summary")


def verify(args):
    payload = {
        "schema_version": "1.0.0",
        "result": "FAIL",
        "authority": "git-head-blob",
        "expected_schema_count": args.expected_count,
        "git_blob_schema_count": 0,
        "embedded_schema_count": 0,
        "manifest_schema_count": 0,
        "git_blob_embedded_match_count": 0,
        "git_blob_manifest_match_count": 0,
        "worktree_diagnostic_mismatch_count": 0,
        "worktree_crlf_false_positive_count": 0,
        "files_rewritten": 0,
        "schemas": [],
        "errors": [],
    }
    try:
        repository = args.repository.resolve(strict=True)
        command = git_command()
        run_git(command, repository, "rev-parse", "--verify", "HEAD^{commit}")
        authority_names = tree_names(command, repository, args.authority_dir)
        embedded_names = tree_names(command, repository, args.embedded_dir)
        manifest = parse_manifest(blob(command, repository, args.manifest))
        payload["git_blob_schema_count"] = len(authority_names)
        payload["embedded_schema_count"] = len(embedded_names)
        payload["manifest_schema_count"] = len(manifest)
        authority_set = set(authority_names)
        if len(authority_names) != args.expected_count:
            payload["errors"].append("unexpected Git authority schema count")
        if set(embedded_names) != authority_set:
            payload["errors"].append("embedded schema set differs from Git authority set")
        if set(manifest) != authority_set:
            payload["errors"].append("manifest schema set differs from Git authority set")

        for name in authority_names:
            authority = blob(command, repository, f"{args.authority_dir}/{name}")
            embedded = blob(command, repository, f"{args.embedded_dir}/{name}") if name in embedded_names else None
            digest = hashlib.sha256(authority).hexdigest()
            embedded_match = embedded == authority
            manifest_match = manifest.get(name) == digest
            payload["git_blob_embedded_match_count"] += int(embedded_match)
            payload["git_blob_manifest_match_count"] += int(manifest_match)
            worktree_path = repository / args.embedded_dir / name
            worktree = worktree_path.read_bytes() if worktree_path.is_file() else None
            worktree_match = worktree == authority
            crlf_only = worktree is not None and worktree != authority and worktree.replace(b"\r\n", b"\n") == authority
            payload["worktree_diagnostic_mismatch_count"] += int(not worktree_match)
            payload["worktree_crlf_false_positive_count"] += int(not worktree_match and crlf_only)
            payload["schemas"].append({
                "name": name,
                "git_blob_sha256": digest,
                "embedded_matches_git_blob": embedded_match,
                "manifest_matches_git_blob": manifest_match,
                "worktree_matches_git_blob": worktree_match,
                "worktree_crlf_only_difference": crlf_only,
            })
            if not embedded_match:
                payload["errors"].append(f"embedded Git blob mismatch: {name}")
            if not manifest_match:
                payload["errors"].append(f"manifest digest mismatch: {name}")
        if not payload["errors"]:
            payload["result"] = "PASS"
    except (json.JSONDecodeError, OSError, RuntimeError, UnicodeDecodeError, ValueError) as exc:
        payload["errors"].append(str(exc))
    write_summary(args.summary, payload)
    print(f"schema_authority={payload['result']}")
    print(f"schema_authority_summary={args.summary}")
    return 0 if payload["result"] == "PASS" else 1


def main():
    parser = argparse.ArgumentParser(description="Verify schema Git blobs, embedded sources, and manifest")
    parser.add_argument("--repository", type=Path)
    parser.add_argument("--authority-dir")
    parser.add_argument("--embedded-dir")
    parser.add_argument("--manifest")
    parser.add_argument("--expected-count", type=int)
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--validate-summary", type=Path)
    args = parser.parse_args()
    try:
        if args.validate_summary:
            validate_summary(args.validate_summary)
            print("schema_authority_summary_validation=PASS")
            return 0
        if None in (args.repository, args.authority_dir, args.embedded_dir, args.manifest, args.expected_count, args.summary):
            parser.error("verification arguments are required")
        return verify(args)
    except (json.JSONDecodeError, OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
