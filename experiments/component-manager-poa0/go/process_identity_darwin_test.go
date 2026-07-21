//go:build darwin

package main

import (
	"os"
	"testing"
)

func TestDarwinProcessStartIdentity(t *testing.T) {
	identity, err := darwinProcessStartIdentity(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	if identity == 0 {
		t.Fatal("process start identity is zero")
	}
}
