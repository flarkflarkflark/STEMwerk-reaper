//go:build windows

// EXPERIMENTAL_DISPOSABLE_POA_ONLY
package main

import "os"

func injectedKill() { os.Exit(137) }
