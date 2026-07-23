#!/usr/bin/env python3
"""Dependency-free Contract v1 structural and semantic validation."""
from __future__ import annotations
import hashlib, json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPERIMENT = ROOT.parent
SCHEMAS = ROOT / "schemas"
EXAMPLES = ROOT / "examples"
NEGATIVE = ROOT / "negative-fixtures"
DRAFT = "https://json-schema.org/draft/2020-12/schema"
SOURCE_SHA = "18aa77c30eab9fd3874730c55da3e6b16883971443a20f3917b7181186c34b23"
KNOWN_NEGATIVE = {
    "semantic:artifact_digest_mismatch", "semantic:runtime_main_required",
    "semantic:backend_incompatible", "semantic:unknown_compatibility",
    "semantic:mixed_generation", "semantic:receipt_invalid",
    "semantic:lease_identity_unknown", "semantic:active_generation_gc",
    "semantic:provenance_untrusted", "semantic:unsupported_schema_major",
    "semantic:same_version_different_digest", "semantic:duplicate_component_identity",
    "policy:unknown_official_trust_root", "policy:official_tofu_forbidden",
    "policy:invalid_signature", "policy:unknown_algorithm", "policy:unsigned_official",
    "policy:revoked_signing_key", "policy:broken_rotation_chain",
    "policy:offline_snapshot_expired", "policy:catalog_sequence_rollback",
    "policy:catalog_digest_fork", "policy:gc_count_protected",
    "policy:gc_age_protected", "policy:gc_suspected_lease",
    "policy:gc_unknown_ownership", "policy:schema_major_unknown",
    "policy:lossy_downgrade", "policy:schema_handshake_mismatch",
    "policy:development_scope_escape", "policy:rollback_revoked",
    "policy:clock_rollback",
}
SCHEMA_DOCS = {}

def load(path: Path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)

def validate(schema, value, where="$"):
    if "$ref" in schema:
        schema = SCHEMA_DOCS[Path(schema["$ref"].split("#", 1)[0]).name]
    errors = []
    expected = schema.get("type")
    if expected:
        kinds = expected if isinstance(expected, list) else [expected]
        ok = any(
            (kind == "object" and isinstance(value, dict))
            or (kind == "array" and isinstance(value, list))
            or (kind == "string" and isinstance(value, str))
            or (kind == "integer" and isinstance(value, int) and not isinstance(value, bool))
            or (kind == "boolean" and isinstance(value, bool))
            or (kind == "null" and value is None)
            for kind in kinds
        )
        if not ok:
            return [f"{where}: expected {kinds}"]
    if "const" in schema and value != schema["const"]:
        errors.append(f"{where}: const mismatch")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{where}: enum mismatch")
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append(f"{where}: too short")
        if "pattern" in schema and not re.fullmatch(schema["pattern"], value):
            errors.append(f"{where}: pattern mismatch")
    if isinstance(value, int) and "minimum" in schema and value < schema["minimum"]:
        errors.append(f"{where}: below minimum")
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{where}: missing {key}")
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in props:
                    errors.append(f"{where}: unexpected {key}")
        for key, item in value.items():
            if key in props:
                errors.extend(validate(props[key], item, f"{where}.{key}"))
    return errors

def main():
    failures = []
    schema_files = sorted(SCHEMAS.glob("*.schema.json"))
    schemas = SCHEMA_DOCS
    ids = set()
    for path in schema_files:
        data = load(path)
        schemas[path.name] = data
        required_meta = {"$schema", "$id", "title", "type", "required", "additionalProperties", "properties"}
        if not required_meta <= data.keys():
            failures.append(f"{path.name}: incomplete metaschema structure")
        if data.get("$schema") != DRAFT:
            failures.append(f"{path.name}: wrong draft")
        if data.get("$id") in ids:
            failures.append(f"{path.name}: duplicate $id")
        ids.add(data.get("$id"))
        if data.get("type") != "object" or data.get("additionalProperties") is not False:
            failures.append(f"{path.name}: root must be strict object")

    unresolved = []
    for path, data in schemas.items():
        for ref in re.findall(r'"\$ref"\s*:\s*"([^"]+)"', json.dumps(data)):
            if not ref.startswith("#") and ref.split("#", 1)[0] not in schemas:
                unresolved.append(f"{path}:{ref}")
    if unresolved:
        failures.extend(unresolved)

    example_files = sorted(EXAMPLES.glob("*.json"))
    covered = set()
    for path in example_files:
        data = load(path)
        ref = data.pop("$schema_ref", None)
        if not ref:
            failures.append(f"{path.name}: missing $schema_ref")
            continue
        schema_name = Path(ref).name
        covered.add(schema_name)
        failures.extend(f"{path.name}: {e}" for e in validate(schemas[schema_name], data))

    expected_schemas = set(schemas)
    if covered != expected_schemas:
        failures.append(f"schema example coverage mismatch: {sorted(expected_schemas-covered)}")

    negative_files = sorted(NEGATIVE.glob("*.json"))
    rejected = 0
    for path in negative_files:
        data = load(path)
        reason = data.get("expected_error")
        schema_name = Path(data.get("$schema_ref", "")).name
        fixture_errors = validate(schemas.get(schema_name, {}), data.get("fixture"))
        if reason in KNOWN_NEGATIVE and fixture_errors:
            rejected += 1
        else:
            failures.append(f"{path.name}: negative fixture was not rejected as expected")

    trace = (ROOT / "CONTRACT_V1_TRACEABILITY.md").read_text(encoding="utf-8")
    requirement_ids = re.findall(r"^\| (CMV1-[A-Z0-9-]+) \|", trace, re.M)
    if len(requirement_ids) != len(set(requirement_ids)):
        failures.append("duplicate requirement ID")
    for decision in ["CORE-001","STATE-001","RECEIPT-001","GEN-001","GEN-002","GEN-003",
                     "PIN-001","LEASE-001","LEASE-002","COMP-001","COMP-002","COMP-003",
                     "MODEL-001","UI-001","PLATFORM-001","CASE-001","CLAIM-001"]:
        if decision not in trace:
            failures.append(f"untraced decision {decision}")

    contract = (ROOT / "COMPONENT_MANAGER_CONTRACT_V1.md").read_text(encoding="utf-8")
    sections = re.findall(r"^## (\d+)\. ", contract, re.M)
    if sections != [str(i) for i in range(1, 45)]:
        failures.append("contract section sequence is not 1..44")
    for term in ["MUST","MUST NOT","REQUIRED","SHALL","SHALL NOT","SHOULD","SHOULD NOT","MAY"]:
        if term not in contract:
            failures.append(f"normative term absent: {term}")

    source = EXPERIMENT / "reports" / "POA_0_EVIDENCE_INDEX.json"
    if hashlib.sha256(source.read_bytes()).hexdigest() != SOURCE_SHA:
        failures.append("source evidence SHA mismatch")
    all_text = "\n".join(
        p.read_text(encoding="utf-8")
        for p in ROOT.rglob("*")
        if p.is_file() and p != Path(__file__).resolve()
    )
    for forbidden in ["/home/flark/.local/share/STEMwerk", ".venv-drumsep-rocm"]:
        if forbidden in all_text:
            failures.append(f"forbidden runtime path: {forbidden}")
    open_policies = (ROOT / "CONTRACT_V1_OPEN_POLICIES.md").read_text(encoding="utf-8")
    if "None." not in open_policies or "BLOCKING_BEFORE_IMPLEMENTATION" in open_policies:
        failures.append("implementation blocker closure not reflected in open policies")
    closure = (ROOT / "CONTRACT_V1_POLICY_CLOSURE.md").read_text(encoding="utf-8")
    if "IMPLEMENTATION_BLOCKERS_CLOSED=5/5" not in closure:
        failures.append("blocker closure marker absent")
    if len(list((ROOT / "decisions").glob("ADR-*.md"))) != 5:
        failures.append("expected five policy ADRs")

    if failures:
        for item in failures:
            print(f"FAIL {item}")
        return 1
    must = len(re.findall(r"\bMUST\b", contract))
    must_not = len(re.findall(r"\bMUST NOT\b", contract))
    print(f"PASS schemas={len(schema_files)} examples={len(example_files)} negative={rejected}/{len(negative_files)}")
    print(f"PASS requirements={len(requirement_ids)} sections={len(sections)} must={must} must_not={must_not}")
    print("PASS metaschema_structure refs traceability normative_language source_evidence scope")
    return 0

if __name__ == "__main__":
    sys.exit(main())
