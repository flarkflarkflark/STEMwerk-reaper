# Component Manager Contract v1

Status: **APPROVED_WITH_IMPLEMENTATION_BLOCKERS**.

This directory contains the normative design derived only from the corrected POA-0
baseline. It is not a production core, CLI, daemon, helper, installer, UI, or REAPER
integration.

## Source baseline

- Evidence freeze: `be0a34a628064aebb8936120d8b23f3846589a0d`
- Native evidence run: `29976687812`
- Evidence-index SHA-256:
  `18aa77c30eab9fd3874730c55da3e6b16883971443a20f3917b7181186c34b23`

## Documents

- `COMPONENT_MANAGER_CONTRACT_V1.md`: normative contract
- `CONTRACT_V1_DECISIONS.md`: resolved and blocked policy decisions
- `CONTRACT_V1_OPEN_POLICIES.md`: implementation blockers and exclusions
- `CONTRACT_V1_TRACEABILITY.md`: architecture-to-schema/test mapping
- `CONTRACT_V1_REVIEW.md`: architecture, security, and implementability reviews
- `schemas/`: Draft 2020-12 record schemas
- `examples/`: schema-valid records
- `negative-fixtures/`: required fail-closed rejection scenarios
- `tests/validate_contract.py`: dependency-free structural contract validation

## Validation

From the repository root:

```sh
python3 experiments/component-manager-poa0/contract-v1/tests/validate_contract.py
python3 experiments/component-manager-poa0/scripts/test-verifier-policy.py
git diff --check
```

The first command validates JSON parsing, Draft 2020-12 schema structure, internal
references, examples, negative semantic fixtures, traceability, unique requirement
IDs, normative language, source evidence, links, and scope boundaries.
