#!/usr/bin/env bash
set -euo pipefail
expected_os=$1 expected_arch=$2
actual_os=$(uname -s)
actual_arch=$(uname -m)
case "$expected_os" in linux) test "$actual_os" = Linux;; macos) test "$actual_os" = Darwin;; *) exit 2;; esac
case "$expected_arch" in x86_64) test "$actual_arch" = x86_64;; arm64) test "$actual_arch" = arm64;; *) exit 2;; esac
if test "$actual_os" = Linux; then filesystem=$(findmnt -T . -no FSTYPE); else filesystem=$(stat -f %T .); fi
file bin/cm-rust bin/cm-go
printf 'NATIVE_OS=%s\nNATIVE_ARCH=%s\nFILESYSTEM=%s\n' "$actual_os" "$actual_arch" "$filesystem"
