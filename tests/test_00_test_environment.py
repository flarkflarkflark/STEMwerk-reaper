"""Fail fast when the canonical development test environment is incomplete."""

from __future__ import annotations

import importlib.util
from pathlib import Path


REQUIRED_TEST_DEPENDENCIES = {
    "pytest": "pytest",
    "PyYAML": "yaml",
    "soundfile": "soundfile",
    "numpy": "numpy",
}


def missing_test_dependencies(find_spec=importlib.util.find_spec):
    return [distribution for distribution, module in REQUIRED_TEST_DEPENDENCIES.items() if find_spec(module) is None]


def test_canonical_test_environment_dependencies_are_available():
    missing = missing_test_dependencies()
    assert not missing, "\n".join(f"TEST_ENV_DEPENDENCY_MISSING={name}" for name in missing)
    print("MACOS_TEST_ENVIRONMENT_DEPENDENCY_GUARD=PASS")


def test_missing_pyyaml_fixture_has_one_actionable_failure():
    def fake_find_spec(module):
        return None if module == "yaml" else object()

    assert missing_test_dependencies(fake_find_spec) == ["PyYAML"]


def test_requirements_dev_defines_the_canonical_guard_dependencies():
    requirements = {
        line.strip().lower() for line in Path("requirements-dev.txt").read_text(encoding="utf-8").splitlines() if line.strip()
    }
    assert requirements == {"pytest", "pyyaml", "soundfile", "numpy"}
