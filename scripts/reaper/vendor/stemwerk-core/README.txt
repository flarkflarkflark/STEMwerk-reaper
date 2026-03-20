STEMwerk-core bundle placeholder
===============================

Place the STEMwerk-core package artifact in this directory so the Windows
installer/bootstrap can install it without relying on PyPI.

Supported formats:
- .whl
- .tar.gz
- .zip

Expected location:
scripts/reaper/vendor/stemwerk-core/

If this folder is empty, the Windows installer will fail with:
stemwerk-core bundle missing from installer payload
