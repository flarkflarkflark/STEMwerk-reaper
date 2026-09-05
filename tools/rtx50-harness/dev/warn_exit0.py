"""Regression fixture: prints to stdout, emits a UserWarning to stderr,
exits 0. Mirrors torch's real cuda/__init__.py UserWarning behavior that
caused STEMwerk #118 harness failure #2.
"""
import sys
import warnings

print("useful stdout output before the warning")
warnings.warn("this is a harmless UserWarning, exactly like torch's cuda init warning", UserWarning)
print("useful stdout output after the warning")
sys.exit(0)
