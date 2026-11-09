"""Start Core from its shipped source directory (design O54, slice S5a).

    <managed python> -I -B <...>/vendor/stemwerk-core/src <module_install arguments>

for example ``... src plan --module drum_kit``. Python runs a directory that
holds ``__main__.py`` by putting that directory first on ``sys.path``, in
isolated mode (``-I``) too, which ignores every ``PYTHON*`` variable and the
user site-packages and does not add the current directory. So the outer layer
can start Core with the freshly published managed Python before any module
venv exists, without installing anything into that Python. ``-B`` keeps the
shipped source free of ``__pycache__``.

The arguments and the output contract are exactly those of
``python -m stemwerk_core.module_install``.
"""

import sys

from stemwerk_core.module_install import main


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
