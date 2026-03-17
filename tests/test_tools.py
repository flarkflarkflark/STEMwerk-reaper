import builtins
import shutil
import subprocess
from tools import separate


def test_build_cmd():
    cmd = separate.build_cmd("/usr/bin/demucs", "htdemucs", "outdir", "in.wav")
    assert "/usr/bin/demucs" in cmd[0]
    assert "htdemucs" in cmd


def test_missing_demucs(monkeypatch):
    monkeypatch.setattr(shutil, "which", lambda name: None)
    class Args:
        input = "in.wav"
        out = "out"
        model = "htdemucs"

    # simulate argv parse failure by asserting non-zero return when demucs missing
    import sys
    sys_argv = sys.argv[:]
    try:
        sys.argv = ["separate.py", "in.wav"]
        rc = separate.main()
        assert rc == 2
    finally:
        sys.argv = sys_argv
