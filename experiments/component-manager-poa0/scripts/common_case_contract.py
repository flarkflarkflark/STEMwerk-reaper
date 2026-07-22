#!/usr/bin/env python3
import argparse
import csv
import json
from collections import Counter
from pathlib import Path


EXPECTED_IDS = [f"CMN-{number:03d}" for number in range(1, 25)]


def validate_records(records, implementation, expected_ids=None):
    expected = expected_ids or EXPECTED_IDS
    selected = [record for record in records if record.get("implementation") == implementation and record.get("case_id")]
    ids = [record["case_id"] for record in selected]
    counts = Counter(ids)
    duplicates = sorted(case_id for case_id, count in counts.items() if count > 1)
    missing = sorted(set(expected) - set(ids))
    extra = sorted(set(ids) - set(expected))
    failed = sorted(record["case_id"] for record in selected if record.get("result") != "PASS")
    incomplete = sorted(
        record["case_id"]
        for record in selected
        if record.get("started") is False or record.get("completed") is False
    )
    problems = []
    if missing: problems.append("missing cases: " + ",".join(missing))
    if extra: problems.append("extra cases: " + ",".join(extra))
    if duplicates: problems.append("duplicate cases: " + ",".join(duplicates))
    if failed: problems.append("failed cases: " + ",".join(failed))
    if incomplete: problems.append("incomplete cases: " + ",".join(incomplete))
    if problems:
        raise ValueError("; ".join(problems))
    return {
        "completed_count": len(selected),
        "duplicate_case_ids": [],
        "extra_case_ids": [],
        "missing_case_ids": [],
        "pass_count": len(selected),
        "selected_count": len(selected),
        "summary": f"{len(selected)}/{len(expected)}",
    }


def records_from_matrix(path):
    with path.open(encoding="utf-8-sig", newline="") as handle:
        rows = csv.DictReader(handle, delimiter="\t")
        return [
            {
                "case_id": row["case"].split()[0],
                "implementation": row["implementation"],
                "started": True,
                "completed": True,
                "result": row["result"].strip(),
            }
            for row in rows
        ]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix", type=Path, required=True)
    parser.add_argument("--implementation", choices=("rust", "go"), required=True)
    parser.add_argument("--expected", default=",".join(EXPECTED_IDS))
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    result = validate_records(records_from_matrix(arguments.matrix), arguments.implementation, arguments.expected.split(","))
    arguments.output.write_text(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    print(result["summary"])


if __name__ == "__main__":
    main()
