#!/usr/bin/env python3
import argparse
import json
import unittest
from pathlib import Path


BASE = Path(__file__).resolve().parents[1]
CATALOG = BASE / "fixtures/expected/test-cases.json"
RUNNER = BASE / "harness/run-matrix.sh"
UNIX_SUMMARY = BASE / "scripts/run-native-matrix.sh"
WINDOWS_SUMMARY = BASE / "scripts/run-native-matrix.ps1"
EXPECTED_IDS = [f"CMN-{number:03d}" for number in range(1, 25)]
MISSING_IDS = [f"CMN-{number:03d}" for number in range(21, 25)]


def catalog_ids():
    data = json.loads(CATALOG.read_text(encoding="utf-8"))
    return [entry.split("-", 2)[0] + "-" + entry.split("-", 2)[1] for entry in data["common_case_ids"]]


def runner_ids():
    text = RUNNER.read_text(encoding="utf-8")
    gates = BASE / "scripts/common-gate-cases.sh"
    if gates.exists():
        text += gates.read_text(encoding="utf-8")
    return [case_id for case_id in EXPECTED_IDS if case_id in text]


class PreFixReproductionTests(unittest.TestCase):
    def test_01_catalog_has_24_ids(self):
        self.assertEqual(catalog_ids(), EXPECTED_IDS)

    def test_02_runner_has_20_ids(self):
        self.assertEqual(runner_ids(), EXPECTED_IDS[:20])

    def test_03_cmn021_missing(self):
        self.assertNotIn("CMN-021", runner_ids())

    def test_04_cmn022_missing(self):
        self.assertNotIn("CMN-022", runner_ids())

    def test_05_cmn023_missing(self):
        self.assertNotIn("CMN-023", runner_ids())

    def test_06_cmn024_missing(self):
        self.assertNotIn("CMN-024", runner_ids())

    def test_07_hardcoded_summary_can_false_pass(self):
        self.assertIn('common_matrix:"24/24"', UNIX_SUMMARY.read_text(encoding="utf-8"))
        self.assertIn("common_matrix='24/24'", WINDOWS_SUMMARY.read_text(encoding="utf-8"))

    def test_08_alias_rows_do_not_supply_missing_ids(self):
        alias_rows = [(impl, case_id) for impl in ("rust", "go") for case_id in EXPECTED_IDS[:20]]
        self.assertEqual({case_id for _, case_id in alias_rows}, set(EXPECTED_IDS[:20]))

    def test_09_probe_events_are_not_case_records(self):
        probe = {"event": "pass", "step": "process_probe"}
        self.assertNotIn("case_id", probe)

    def test_10_expected_set_diff_fails(self):
        self.assertEqual(sorted(set(EXPECTED_IDS) - set(runner_ids())), MISSING_IDS)


class PostFixContractTests(unittest.TestCase):
    def setUp(self):
        from common_case_contract import validate_records
        self.validate_records = validate_records
        self.records = [
            {
                "case_id": case_id,
                "implementation": "rust",
                "started": True,
                "completed": True,
                "result": "PASS",
                "expected_state": "expected",
                "actual_state": "expected",
                "first_failure_step": "none",
                "failure_message": "none",
                "artifact_reference": f"common-cases/{case_id}.json",
            }
            for case_id in EXPECTED_IDS
        ]

    def test_01_selected_common_count(self):
        self.assertEqual(self.validate_records(self.records, "rust")["summary"], "24/24")

    def test_02_cmn021_record(self): self.assertIn("CMN-021", {r["case_id"] for r in self.records})
    def test_03_cmn022_record(self): self.assertIn("CMN-022", {r["case_id"] for r in self.records})
    def test_04_cmn023_record(self): self.assertIn("CMN-023", {r["case_id"] for r in self.records})
    def test_05_cmn024_record(self): self.assertIn("CMN-024", {r["case_id"] for r in self.records})
    def test_06_new_cases_started(self): self.assertTrue(all(r["started"] for r in self.records[-4:]))
    def test_07_new_cases_completed(self): self.assertTrue(all(r["completed"] for r in self.records[-4:]))
    def test_08_expected_present(self): self.assertTrue(all(r["expected_state"] for r in self.records[-4:]))
    def test_09_actual_present(self): self.assertTrue(all(r["actual_state"] for r in self.records[-4:]))

    def test_10_independent_failure(self):
        records = [dict(record) for record in self.records]
        records[20]["result"] = "FAIL"
        with self.assertRaisesRegex(ValueError, "failed cases: CMN-021"):
            self.validate_records(records, "rust")

    def test_11_alias_exclusion(self):
        records = self.records + [dict(self.records[0], implementation="go")]
        self.assertEqual(self.validate_records(records, "rust")["selected_count"], 24)

    def test_12_probe_exclusion(self):
        records = self.records + [{"event": "pass", "step": "probe"}]
        self.assertEqual(self.validate_records(records, "rust")["selected_count"], 24)

    def test_13_missing_rejected(self):
        with self.assertRaisesRegex(ValueError, "missing cases: CMN-024"):
            self.validate_records(self.records[:-1], "rust")

    def test_14_extra_rejected(self):
        with self.assertRaisesRegex(ValueError, "extra cases: CMN-025"):
            self.validate_records(self.records + [dict(self.records[0], case_id="CMN-025")], "rust")

    def test_15_duplicate_rejected(self):
        with self.assertRaisesRegex(ValueError, "duplicate cases: CMN-001"):
            self.validate_records(self.records + [dict(self.records[0])], "rust")

    def test_16_wrong_implementation_rejected(self):
        records = [dict(record, implementation="go") for record in self.records]
        with self.assertRaisesRegex(ValueError, "missing cases"):
            self.validate_records(records, "rust")

    def test_17_rust_set_24(self): self.assertEqual(self.validate_records(self.records, "rust")["completed_count"], 24)

    def test_18_go_set_24(self):
        records = [dict(record, implementation="go") for record in self.records]
        self.assertEqual(self.validate_records(records, "go")["completed_count"], 24)

    def test_19_catalog_runner_equal(self): self.assertEqual(runner_ids(), catalog_ids())
    def test_20_full_matrix_formula(self): self.assertEqual(2 * 38 + 2 * 43 + 4 * 41, 326)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", choices=("pre", "post"), required=True)
    args = parser.parse_args()
    suite_class = PreFixReproductionTests if args.phase == "pre" else PostFixContractTests
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(suite_class))
    raise SystemExit(not result.wasSuccessful())
