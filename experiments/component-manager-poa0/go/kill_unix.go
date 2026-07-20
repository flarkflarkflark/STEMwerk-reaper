//go:build !windows

// EXPERIMENTAL_DISPOSABLE_POA_ONLY
package main

import (
	"os"
	"syscall"
)

func injectedKill() { _ = syscall.Kill(os.Getpid(), syscall.SIGKILL) }
