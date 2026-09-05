"""Regression fixture: writes to stderr and exits non-zero - a genuine
failure that the harness MUST still detect and report as a failure.
"""
import sys

print("this process is about to fail", file=sys.stderr)
sys.exit(7)
