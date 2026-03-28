STEMwerk-core bundled source
============================

This directory is the canonical bundled STEMwerk-core source tree used by
installers, setup/bootstrap, and ReaPack payloads.

Expected contents:
- pyproject.toml
- src/stemwerk_core/__init__.py
- src/stemwerk_core/devices.py
- src/stemwerk_core/models.py
- src/stemwerk_core/progress.py
- src/stemwerk_core/separator.py

Location:
scripts/reaper/vendor/stemwerk-core/

Do not rely on an old wheel fallback here. If the source files are missing,
setup should fail clearly instead of silently installing a stale package.
