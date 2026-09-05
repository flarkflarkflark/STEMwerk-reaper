"""Regression fixture: sleeps for N seconds (default 12) then exits 0, to
exercise Invoke-NativeProcess's -HeartbeatSeconds behavior without waiting
for a real multi-minute pip install.
"""
import sys
import time

seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 12.0
print(f"sleeping for {seconds}s")
time.sleep(seconds)
print("done sleeping")
sys.exit(0)
